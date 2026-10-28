import Foundation
import XCTest
import SkyBridgeOpus

final class SkyBridgeOpusStreamEncoderTests: XCTestCase {
    private enum Failure: Error { case denied, sink }

    func testFinitePartitionsMatchContinuousNativeEncodingAndDecodeCounts() throws {
        var cases = 0
        for channels in [1, 2] {
            for bitrate in [128_000, 192_000, 256_000] {
                for frames in [1, 17, 648, 649, 959, 960, 961, 3517, 48_913] {
                    let pcm = samples(frames: frames, channels: channels)
                    let whole = try encode(pcm, channels: channels, bitrate: bitrate, partitions: [4096])
                    let split = try encode(pcm, channels: channels, bitrate: bitrate, partitions: [1, 17, 511, 3, 960, 4096])
                    XCTAssertEqual(whole.packets, split.packets)
                    XCTAssertEqual(whole.receipt, split.receipt)
                    let reference = try SkyBridgeOpusEncoder(configuration: configuration(channels, bitrate))
                    let skip = try reference.lookaheadSamplesPerChannel()
                    XCTAssertEqual(whole.format.preSkipFrames, skip)
                    let count = (frames + skip + 959) / 960
                    let padded = pcm + [Int16](repeating: 0, count: (count * 960 - frames) * channels)
                    var referencePackets: [Data] = []
                    for index in 0..<count {
                        referencePackets.append(try reference.encode(pcm16Interleaved:
                            Array(padded[(index * 960 * channels)..<((index + 1) * 960 * channels)])))
                    }
                    XCTAssertEqual(whole.packets.map(\.bytes), referencePackets)
                    let decoder = try SkyBridgeOpusStreamDecoder(format: whole.format)
                    var actual = Data()
                    for packet in whole.packets {
                        if let chunk = try decoder.append(packet: packet.bytes, sequence: packet.sequence) { actual.append(chunk.pcm16LE) }
                    }
                    let completion = try decoder.finish(expectedPCMFrames: UInt64(frames))
                    actual.append(completion.finalChunk.pcm16LE)
                    let continuous = try SkyBridgeOpusDecoder(channels: channels)
                    var decoded: [Int16] = []
                    for packet in referencePackets { decoded.append(contentsOf: try continuous.decode(packet: packet)) }
                    let expected = decoded[(skip * channels)..<((skip + frames) * channels)]
                    XCTAssertEqual(actual, littleEndian(expected))
                    XCTAssertEqual(actual.count, frames * channels * 2)
                    XCTAssertEqual(completion.trailingPaddingFrames, whole.receipt.trailingPaddingFrames)
                    XCTAssertEqual(whole.receipt.packetCount, UInt64(count))
                    XCTAssertTrue((0..<960).contains(whole.receipt.trailingPaddingFrames))
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, 54)
    }

    func testFiniteSourceMustBeNonemptyBoundedAndExact() throws {
        for frames in [UInt64(0), SkyBridgeOpusStreamEncoder.maximumSourceFrames + 1] {
            XCTAssertThrowsError(try SkyBridgeOpusStreamEncoder(channels: 2, bitrate: 192_000,
                expectedSourceFrames: frames, requireAuthorization: {})) {
                XCTAssertEqual($0 as? SkyBridgeOpusEncodeError, .invalidSourceFrameCount)
            }
        }
        XCTAssertThrowsError(try SkyBridgeOpusStreamEncoder(channels: 3, bitrate: 192_000,
            expectedSourceFrames: 1, requireAuthorization: {}))
        let short = try encoder(frames: 18)
        try short.append(pcm16Interleaved: [Int16](repeating: 1, count: 34)) { _ in XCTFail("Partial input emitted") }
        XCTAssertThrowsError(try short.finish { _ in XCTFail("Short source padded into success") }) {
            XCTAssertEqual($0 as? SkyBridgeOpusEncodeError, .incompleteSource)
        }
        XCTAssertEqual(short.state, .failed); XCTAssertTrue(short.resourcesReleased)
        XCTAssertThrowsError(try short.append(pcm16Interleaved: [1, 1]) { _ in XCTFail("Failed owner resumed") })
        let overrun = try encoder(frames: 1)
        XCTAssertThrowsError(try overrun.append(pcm16Interleaved: [1, 1, 1, 1]) { _ in XCTFail("Overrun emitted") }) {
            XCTAssertEqual($0 as? SkyBridgeOpusEncodeError, .sourceOverrun)
        }
        XCTAssertEqual(overrun.acceptedSourceFrames, 0); XCTAssertTrue(overrun.resourcesReleased)
    }

    func testWholeFrameAndChunkBoundsFailBeforeAnyPacket() throws {
        for input in [[], [1], [Int16](repeating: 0, count: 4097 * 2)] {
            let owner = try encoder(frames: 10_000)
            XCTAssertThrowsError(try owner.append(pcm16Interleaved: input) { _ in XCTFail("Invalid PCM emitted") }) {
                XCTAssertEqual($0 as? SkyBridgeOpusEncodeError, .invalidPCMCount(input.count))
            }
            XCTAssertEqual(owner.acceptedSourceFrames, 0)
            XCTAssertEqual(owner.emittedPackets, 0); XCTAssertTrue(owner.resourcesReleased)
        }
    }

    func testCancellationDropsBufferedInputAndCannotFinish() throws {
        let owner = try encoder(frames: 100)
        try owner.append(pcm16Interleaved: [Int16](repeating: 1, count: 34)) { _ in XCTFail("Partial input emitted") }
        XCTAssertEqual(owner.bufferedPCMFrames, 17)
        owner.cancel(); owner.cancel()
        XCTAssertEqual(owner.state, .cancelled); XCTAssertTrue(owner.resourcesReleased)
        XCTAssertEqual(owner.bufferedPCMFrames, 0)
        XCTAssertThrowsError(try owner.finish { _ in XCTFail("Cancellation completed") })
    }

    func testAuthorityLossBeforeEmissionIsSticky() throws {
        var allowed = true
        let owner = try SkyBridgeOpusStreamEncoder(channels: 2, bitrate: 192_000,
            expectedSourceFrames: 960, requireAuthorization: { if !allowed { throw Failure.denied } })
        try owner.append(pcm16Interleaved: [1, 1]) { _ in XCTFail("Partial input emitted") }
        allowed = false
        XCTAssertThrowsError(try owner.append(pcm16Interleaved: [Int16](repeating: 1, count: 959 * 2)) { _ in XCTFail("Revoked audio emitted") }) {
            XCTAssertEqual($0 as? Failure, .denied)
        }
        allowed = true
        XCTAssertThrowsError(try owner.finish { _ in XCTFail("Revoked owner recovered") }) { XCTAssertEqual($0 as? Failure, .denied) }
        XCTAssertTrue(owner.resourcesReleased)
    }

    func testRevocationAfterSinkReturnPreventsFurtherPacketsAndCompletion() throws {
        var allowed = true; var delivered = 0
        let owner = try SkyBridgeOpusStreamEncoder(channels: 2, bitrate: 192_000,
            expectedSourceFrames: 1920, requireAuthorization: { if !allowed { throw Failure.denied } })
        XCTAssertThrowsError(try owner.append(pcm16Interleaved: [Int16](repeating: 1, count: 1920 * 2)) { _ in
            delivered += 1; allowed = false
        }) { XCTAssertEqual($0 as? Failure, .denied) }
        XCTAssertEqual(delivered, 1); XCTAssertEqual(owner.state, .failed); XCTAssertTrue(owner.resourcesReleased)
        XCTAssertThrowsError(try owner.finish { _ in XCTFail("Revoked tail emitted") })
    }

    func testSinkFailureCannotBeRetriedOrReportedAsComplete() throws {
        let owner = try encoder(frames: 1920); var delivered = 0
        XCTAssertThrowsError(try owner.append(pcm16Interleaved: [Int16](repeating: 1, count: 1920 * 2)) { _ in
            delivered += 1; throw Failure.sink
        }) { XCTAssertEqual($0 as? Failure, .sink) }
        XCTAssertEqual(delivered, 1); XCTAssertTrue(owner.resourcesReleased)
        XCTAssertThrowsError(try owner.finish { _ in XCTFail("Failed output retried") }) { XCTAssertEqual($0 as? Failure, .sink) }
    }

    func testCaughtSinkReentryStillTerminatesTheOuterOperation() throws {
        let owner = try encoder(frames: 1920)
        XCTAssertThrowsError(try owner.append(pcm16Interleaved: [Int16](repeating: 1, count: 1920 * 2)) { _ in
            XCTAssertThrowsError(try owner.append(pcm16Interleaved: [1, 1]) { _ in XCTFail("Reentrant packet") })
        }) { XCTAssertEqual($0 as? SkyBridgeOpusEncodeError, .invalidState) }
        XCTAssertEqual(owner.state, .failed); XCTAssertTrue(owner.resourcesReleased)
    }

    func testAuthorityReentryIsFencedBeforeCallingAuthorityAgain() throws {
        var owner: SkyBridgeOpusStreamEncoder?; var reenter = false; var calls = 0
        owner = try SkyBridgeOpusStreamEncoder(channels: 2, bitrate: 192_000, expectedSourceFrames: 960,
            requireAuthorization: {
                calls += 1
                if reenter, let owner {
                    reenter = false
                    XCTAssertThrowsError(try owner.finish { _ in XCTFail("Reentrant finish") })
                }
            })
        let encoder = try XCTUnwrap(owner)
        let initialCalls = calls; reenter = true
        XCTAssertThrowsError(try encoder.append(pcm16Interleaved: [1, 1]) { _ in XCTFail("Reentrant audio") })
        XCTAssertEqual(calls, initialCalls + 1)
        XCTAssertEqual(encoder.acceptedSourceFrames, 0); XCTAssertTrue(encoder.resourcesReleased)
    }

    func testCancellationFromSinkWaitsForOperationExit() throws {
        let owner = try encoder(frames: 960)
        XCTAssertThrowsError(try owner.append(pcm16Interleaved: [Int16](repeating: 1, count: 1920)) { _ in
            owner.cancel()
            XCTAssertFalse(owner.resourcesReleased)
        })
        XCTAssertEqual(owner.state, .cancelled); XCTAssertTrue(owner.resourcesReleased)
    }

    func testTwoMinuteInputUsesBoundedChunksAndExactFinalCounters() throws {
        let frames = UInt64(120 * 48_000)
        let owner = try encoder(frames: frames)
        var packets: UInt64 = 0
        let accept: (SkyBridgeOpusEncodedPacket) -> Void = { packet in
            XCTAssertEqual(packet.sequence, packets); XCTAssertEqual(packet.firstDecodedFrame, packets * 960)
            XCTAssertEqual(packet.bytes.count, 480); packets += 1
        }
        while owner.acceptedSourceFrames < frames {
            let count = Int(min(4096, frames - owner.acceptedSourceFrames))
            try owner.append(pcm16Interleaved: samples(frames: count, channels: 2), emit: accept)
            XCTAssertLessThan(owner.bufferedPCMFrames, 960)
        }
        let result = try owner.finish(emit: accept)
        XCTAssertEqual(result.sourceFrames, frames)
        XCTAssertEqual(result.packetCount, packets)
        XCTAssertEqual(result.packetCount * 960, frames + UInt64(result.preSkipFrames + result.trailingPaddingFrames))
        XCTAssertTrue(owner.resourcesReleased)
    }

    private func configuration(_ channels: Int, _ bitrate: Int) -> SkyBridgeOpusConfiguration {
        SkyBridgeOpusConfiguration(channels: channels, bitrate: bitrate, complexity: 8,
            expectedPacketLossPercent: 0, inBandFECEnabled: false, dtxEnabled: false,
            application: .audio, signal: .music, bitrateMode: .constant)
    }

    private func encoder(frames: UInt64) throws -> SkyBridgeOpusStreamEncoder {
        try SkyBridgeOpusStreamEncoder(channels: 2, bitrate: 192_000, expectedSourceFrames: frames, requireAuthorization: {})
    }

    private func encode(_ pcm: [Int16], channels: Int, bitrate: Int, partitions: [Int]) throws ->
        (format: SkyBridgeOpusStreamFormat, packets: [SkyBridgeOpusEncodedPacket], receipt: SkyBridgeOpusEncodeCompletion) {
        let owner = try SkyBridgeOpusStreamEncoder(channels: channels, bitrate: bitrate,
            expectedSourceFrames: UInt64(pcm.count / channels), requireAuthorization: {})
        var packets: [SkyBridgeOpusEncodedPacket] = []; var offset = 0; var step = 0
        while offset < pcm.count {
            let end = min(pcm.count, offset + partitions[step % partitions.count] * channels)
            try owner.append(pcm16Interleaved: Array(pcm[offset..<end])) { packets.append($0) }
            XCTAssertLessThan(owner.bufferedPCMFrames, 960)
            offset = end; step += 1
        }
        let result = try owner.finish { packets.append($0) }
        XCTAssertEqual(owner.state, .finished); XCTAssertTrue(owner.resourcesReleased)
        return (owner.format, packets, result)
    }

    private func samples(frames: Int, channels: Int) -> [Int16] {
        (0..<(frames * channels)).map { index in
            let frame = index / channels
            if frame == 0 { return index % channels == 0 ? 20_000 : -20_000 }
            if frame == frames - 1 { return index % channels == 0 ? -16_000 : 16_000 }
            return Int16((sin(Double(frame) * (index % channels == 0 ? 0.073 : 0.217)) * 6000).rounded())
        }
    }

    private func littleEndian(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
}
