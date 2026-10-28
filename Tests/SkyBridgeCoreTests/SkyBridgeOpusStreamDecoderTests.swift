import CryptoKit
import Foundation
import XCTest
import SkyBridgeOpus

final class SkyBridgeOpusStreamDecoderTests: XCTestCase {
    private struct Fixtures: Decodable { let streams: [Fixture] }
    private struct Fixture: Decodable {
        let name: String
        let shouldComplete: Bool
        let expectedPCMFrames: UInt64
        let channels: Int
        let bitrate: Int
        let preSkipFrames: Int
        let expectedDecodedSHA256: String?
        let packetBase64: [String]

        func format(preSkip: Int? = nil) throws -> SkyBridgeOpusStreamFormat {
            try SkyBridgeOpusStreamFormat(channels: channels, bitrate: bitrate, preSkipFrames: preSkip ?? preSkipFrames)
        }
        func packets() throws -> [Data] { try packetBase64.map { try XCTUnwrap(Data(base64Encoded: $0)) } }
    }

    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "opus-decoder-v1", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url)).streams
    }

    private func mediumFixture() throws -> Fixture {
        try XCTUnwrap(fixtures().first { $0.name == "padded-48913-192000-constant-separate" })
    }

    func testRecordedAndroidPacketsMatchFullStreamReference() throws {
        let cases = try fixtures().filter(\.shouldComplete)
        XCTAssertEqual(cases.count, 5)
        for value in cases {
            let decoder = try SkyBridgeOpusStreamDecoder(format: value.format())
            var pcm = Data()
            for (sequence, packet) in try value.packets().enumerated() {
                if let chunk = try decoder.append(packet: packet, sequence: UInt64(sequence)) {
                    XCTAssertEqual(chunk.firstPCMFrame, UInt64(pcm.count / (value.channels * 2)))
                    XCTAssertEqual(chunk.pcm16LE.count, chunk.frameCount * value.channels * 2)
                    pcm.append(chunk.pcm16LE)
                }
                XCTAssertLessThanOrEqual(decoder.bufferedPCMFrames, 960)
            }
            XCTAssertLessThan(decoder.emittedPCMFrames, value.expectedPCMFrames)
            let end = try decoder.finish(expectedPCMFrames: value.expectedPCMFrames)
            XCTAssertEqual(end.finalChunk.firstPCMFrame, UInt64(pcm.count / (value.channels * 2)))
            pcm.append(end.finalChunk.pcm16LE)
            XCTAssertEqual(pcm.count, Int(value.expectedPCMFrames) * value.channels * 2)
            XCTAssertEqual(SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined(), value.expectedDecodedSHA256)
            XCTAssertEqual(end.totalPCMFrames, value.expectedPCMFrames)
            XCTAssertEqual(end.discardedDelayFrames, value.preSkipFrames)
            XCTAssertEqual(end.trailingPaddingFrames,
                           value.packetBase64.count * 960 - value.preSkipFrames - Int(value.expectedPCMFrames))
            XCTAssertEqual(decoder.state, .finished)
            XCTAssertEqual(decoder.bufferedPCMFrames, 0)
            XCTAssertThrowsError(try decoder.finish(expectedPCMFrames: value.expectedPCMFrames))
            XCTAssertEqual(decoder.state, .finished)
        }
    }

    func testNativeEOSWithoutEnoughCodedSamplesCannotComplete() throws {
        let value = try XCTUnwrap(fixtures().first { !$0.shouldComplete })
        let decoder = try SkyBridgeOpusStreamDecoder(format: value.format())
        for (index, packet) in try value.packets().enumerated() {
            _ = try decoder.append(packet: packet, sequence: UInt64(index))
        }
        XCTAssertEqual(decoder.decodedFramesIncludingDelay, 48960)
        XCTAssertThrowsError(try decoder.finish(expectedPCMFrames: 48913)) {
            XCTAssertEqual($0 as? SkyBridgeOpusStreamError, .invalidEnd)
        }
        XCTAssertEqual(decoder.state, .failed)
        XCTAssertEqual(decoder.bufferedPCMFrames, 0)
    }

    func testSequenceFailureIsTerminalAndNeverReleasesHeldData() throws {
        let fixture = try mediumFixture(), packets = try fixture.packets()
        for sequence in [UInt64(0), 2, UInt64.max] {
            let decoder = try SkyBridgeOpusStreamDecoder(format: fixture.format())
            XCTAssertNil(try decoder.append(packet: packets[0], sequence: 0))
            XCTAssertThrowsError(try decoder.append(packet: packets[1], sequence: sequence)) {
                XCTAssertEqual($0 as? SkyBridgeOpusStreamError, .unexpectedSequence(expected: 1, actual: sequence))
            }
            XCTAssertEqual(decoder.emittedPCMFrames, 0)
            XCTAssertEqual(decoder.acceptedPackets, 1)
            XCTAssertEqual(decoder.bufferedPCMFrames, 0)
            XCTAssertEqual(decoder.state, .failed)
            XCTAssertThrowsError(try decoder.append(packet: packets[1], sequence: 1))
        }
    }

    func testMalformedSizeAndDurationDoNotEnterConcealment() throws {
        let fixture = try mediumFixture(), first = try fixture.packets()[0]
        var shortDuration = first; shortDuration[0] = 16 << 3 // Single 2.5 ms frame.
        for packet in [Data(), first.dropLast(), first + Data([0]), shortDuration] {
            let decoder = try SkyBridgeOpusStreamDecoder(format: fixture.format())
            XCTAssertThrowsError(try decoder.append(packet: packet, sequence: 0))
            XCTAssertEqual(decoder.acceptedPackets, 0)
            XCTAssertEqual(decoder.decodedFramesIncludingDelay, 0)
            XCTAssertEqual(decoder.bufferedPCMFrames, 0)
            XCTAssertEqual(decoder.state, .failed)
        }
    }

    func testCancellationReleasesHeldTailAndDoesNotInventCompletion() throws {
        let fixture = try mediumFixture(), first = try fixture.packets()[0]
        let decoder = try SkyBridgeOpusStreamDecoder(format: fixture.format())
        XCTAssertNil(try decoder.append(packet: first, sequence: 0))
        XCTAssertEqual(decoder.bufferedPCMFrames, 648)
        decoder.cancel(); decoder.cancel()
        XCTAssertEqual(decoder.state, .cancelled)
        XCTAssertEqual(decoder.bufferedPCMFrames, 0)
        XCTAssertEqual(decoder.emittedPCMFrames, 0)
        XCTAssertThrowsError(try decoder.finish(expectedPCMFrames: 648))
        XCTAssertThrowsError(try decoder.append(packet: first, sequence: 1))
    }

    func testDelayAcrossMultiplePacketsRemainsBounded() throws {
        let fixture = try mediumFixture(), packets = try fixture.packets()
        let decoder = try SkyBridgeOpusStreamDecoder(format: fixture.format(preSkip: 3840))
        for index in 0..<5 {
            XCTAssertNil(try decoder.append(packet: packets[index], sequence: UInt64(index)))
            XCTAssertEqual(decoder.emittedPCMFrames, 0)
            XCTAssertLessThanOrEqual(decoder.bufferedPCMFrames, 960)
        }
        let first = try XCTUnwrap(decoder.append(packet: packets[5], sequence: 5))
        XCTAssertEqual(first.firstPCMFrame, 0)
        XCTAssertEqual(first.frameCount, 960)
        decoder.cancel()
    }

    func testInvalidEndAndProfileAreExplicitFailures() throws {
        let fixture = try mediumFixture(), packet = try fixture.packets()[0]
        for count in [UInt64(0), 649, UInt64.max] {
            let decoder = try SkyBridgeOpusStreamDecoder(format: fixture.format())
            _ = try decoder.append(packet: packet, sequence: 0)
            XCTAssertThrowsError(try decoder.finish(expectedPCMFrames: count))
            XCTAssertEqual(decoder.state, .failed)
            XCTAssertEqual(decoder.emittedPCMFrames, 0)
        }
        XCTAssertThrowsError(try SkyBridgeOpusStreamDecoder(format: fixture.format()).finish(expectedPCMFrames: 1))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(sampleRate: 44100, bitrate: 192000, preSkipFrames: 312))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(channels: 0, bitrate: 192000, preSkipFrames: 312))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(channels: 3, bitrate: 192000, preSkipFrames: 312))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(frameSamples: 480, bitrate: 192000, preSkipFrames: 312))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(bitrate: Int.max, preSkipFrames: 312))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(bitrate: 192000, preSkipFrames: -1))
        XCTAssertThrowsError(try SkyBridgeOpusStreamFormat(bitrate: 192000, preSkipFrames: 3841))
    }

    func testMonoUsesNativeCodecAndTwoBytesPerPCMFrame() throws {
        let encoder = try SkyBridgeOpusEncoder(configuration: .init(channels: 1, bitrate: 128000, complexity: 8,
            expectedPacketLossPercent: 0, inBandFECEnabled: false, bitrateMode: .constant))
        let delay = try encoder.lookaheadSamplesPerChannel()
        let decoder = try SkyBridgeOpusStreamDecoder(format: .init(channels: 1, bitrate: 128000, preSkipFrames: delay))
        let reference = try SkyBridgeOpusDecoder(channels: 1)
        let sourceFrames = 2048, total = (sourceFrames + delay + 959) / 960 * 960
        var streamed = Data(), complete: [Int16] = []
        for start in stride(from: 0, to: total, by: 960) {
            let pcm: [Int16] = (start..<(start + 960)).map { index in
                index < sourceFrames ? Int16((sin(Double(index) * 0.073) * 8000).rounded()) : 0
            }
            let packet = try encoder.encode(pcm16Interleaved: pcm)
            complete.append(contentsOf: try reference.decode(packet: packet))
            if let chunk = try decoder.append(packet: packet, sequence: UInt64(start / 960)) { streamed.append(chunk.pcm16LE) }
        }
        let end = try decoder.finish(expectedPCMFrames: UInt64(sourceFrames))
        streamed.append(end.finalChunk.pcm16LE)
        let expected = complete[delay..<(delay + sourceFrames)].map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(streamed, expected)
        XCTAssertEqual(streamed.count, sourceFrames * 2)
    }
}
