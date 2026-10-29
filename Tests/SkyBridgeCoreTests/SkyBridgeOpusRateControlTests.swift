import Foundation
import XCTest
import SkyBridgeOpus

final class SkyBridgeOpusRateControlTests: XCTestCase {
    private func configuration(bitrate: Int, mode: SkyBridgeOpusBitrateMode) -> SkyBridgeOpusConfiguration {
        SkyBridgeOpusConfiguration(bitrate: bitrate, complexity: 8, expectedPacketLossPercent: 0,
            inBandFECEnabled: false, bitrateMode: mode)
    }

    private func pcm(block: Int) -> [Int16] {
        (0..<1920).map { index in
            let frame = block * 960 + index / 2
            return Int16((sin(Double(frame) * (index % 2 == 0 ? 0.073 : 0.217)) * 8000).rounded())
        }
    }

    func testConstantBitrateKeepsTwentyMillisecondPacketBudget() throws {
        for bitrate in [128_000, 192_000, 256_000] {
            let encoder = try SkyBridgeOpusEncoder(configuration: configuration(bitrate: bitrate, mode: .constant))
            let decoder = try SkyBridgeOpusDecoder()
            for block in 0..<16 {
                let packet = try encoder.encode(pcm16Interleaved: pcm(block: block))
                XCTAssertEqual(packet.count, bitrate / 400)
                XCTAssertEqual(try decoder.decode(packet: packet).count, 1920)
            }
        }
    }

    func testExistingDefaultMatchesExplicitConstrainedVariableMode() throws {
        let implicit = SkyBridgeOpusConfiguration(bitrate: 192_000, complexity: 8, expectedPacketLossPercent: 0,
                                                 inBandFECEnabled: false)
        let first = try SkyBridgeOpusEncoder(configuration: implicit)
        let second = try SkyBridgeOpusEncoder(configuration: configuration(bitrate: 192_000, mode: .constrainedVariable))
        XCTAssertEqual(implicit.bitrateMode, .constrainedVariable)
        XCTAssertEqual(try first.lookaheadSamplesPerChannel(), try second.lookaheadSamplesPerChannel())
        for block in 0..<16 {
            XCTAssertEqual(try first.encode(pcm16Interleaved: pcm(block: block)),
                           try second.encode(pcm16Interleaved: pcm(block: block)))
        }
    }

    func testReconfigurationRestoresConstantBudgetAfterVariableMode() throws {
        let encoder = try SkyBridgeOpusEncoder(configuration: configuration(bitrate: 128_000, mode: .constant))
        for (mode, bitrate) in [(SkyBridgeOpusBitrateMode.variable, 192_000), (.constant, 128_000),
                                (.constrainedVariable, 256_000), (.constant, 256_000)] {
            let next = configuration(bitrate: bitrate, mode: mode)
            try encoder.reconfigure(next)
            XCTAssertEqual(encoder.configuration, next)
            var sizes: Set<Int> = []
            for block in 0..<16 {
                let packet = try encoder.encode(pcm16Interleaved: pcm(block: block))
                sizes.insert(packet.count)
                if mode == .constant { XCTAssertEqual(packet.count, bitrate / 400) }
            }
            if mode != .constant { XCTAssertGreaterThan(sizes.count, 1) }
        }
    }

    func testRejectedReconfigurationLeavesActivePacketBudgetUntouched() throws {
        for invalidLoss in [false, true] {
            let original = configuration(bitrate: 192_000, mode: .constant)
            let encoder = try SkyBridgeOpusEncoder(configuration: original)
            for block in 0..<8 { _ = try encoder.encode(pcm16Interleaved: pcm(block: block)) }
            let rejected = SkyBridgeOpusConfiguration(bitrate: 256_000, complexity: invalidLoss ? 8 : 11,
                expectedPacketLossPercent: invalidLoss ? 101 : 0, inBandFECEnabled: false, bitrateMode: .variable)
            XCTAssertThrowsError(try encoder.reconfigure(rejected))
            XCTAssertEqual(encoder.configuration, original)
            for block in 8..<13 {
                XCTAssertEqual(try encoder.encode(pcm16Interleaved: pcm(block: block)).count, 480,
                               "A rejected update must not change the active CBR packet budget")
            }
        }
    }

    func testInvalidIntegerControlsThrowBeforeNativeAllocationOrConversion() {
        let invalid: [(Int, Int, Int)] = [
            (Int.max, 8, 0), (Int.min, 8, 0), (0, 8, 0), (-2, 8, 0),
            (192_000, -1, 0), (192_000, 11, 0), (192_000, Int.max, 0),
            (192_000, 8, -1), (192_000, 8, 101), (192_000, 8, Int.min)
        ]
        for (bitrate, complexity, loss) in invalid {
            let value = SkyBridgeOpusConfiguration(bitrate: bitrate, complexity: complexity,
                expectedPacketLossPercent: loss, inBandFECEnabled: false, bitrateMode: .constant)
            XCTAssertThrowsError(try SkyBridgeOpusEncoder(configuration: value))
        }
    }
}
