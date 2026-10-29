import XCTest

final class TopBarNetworkStatusServiceTests: XCTestCase {
    func testTopBarNetworkStatusRefreshIsNetworkEventDriven() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("Sources/SkyBridgeCore/Network/TopBarNetworkStatusService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("NWPathMonitor()"))
        XCTAssertTrue(source.contains("handleNetworkPathUpdate"))
        XCTAssertFalse(source.contains("Timer.scheduledTimer"))
        XCTAssertFalse(source.contains("speedSamplingInterval"))
    }
}
