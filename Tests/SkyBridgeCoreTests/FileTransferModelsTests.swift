import XCTest
@testable import SkyBridgeCore

final class FileTransferModelsTests: XCTestCase {
    func testVideoConfigEncodingDecoding() throws {
        let cfg = VideoTransferConfiguration.highQuality
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(VideoTransferConfiguration.self, from: data)
        XCTAssertEqual(decoded.resolution, .uhd4k)
        XCTAssertEqual(decoded.frameRate, .fps60)
        XCTAssertTrue(decoded.enableHardwareAcceleration)
    }
    func testEstimatedDataRateAndOptimizedConfig() {
        let cfg = VideoTransferConfiguration.highPerformance
        XCTAssertGreaterThan(cfg.estimatedDataRate, 0)
        let opt = cfg.optimizedTransferConfiguration
        XCTAssertTrue(opt.compressionEnabled)
        XCTAssertTrue(opt.encryptionEnabled)
        XCTAssertEqual(opt.chunkSize, VideoResolution.apple5k.recommendedChunkSize)
    }
}
