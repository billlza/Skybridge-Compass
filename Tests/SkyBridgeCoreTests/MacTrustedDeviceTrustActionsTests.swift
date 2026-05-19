import XCTest

final class MacTrustedDeviceTrustActionsTests: XCTestCase {
    func testMacTrustedDeviceDetailSplitsRepairAndFullForgetSemantics() throws {
        let detailSource = try repositorySource("Sources/SkyBridgeCompassApp/Views/TrustedDeviceDetailView.swift")
        let discoverySource = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")

        XCTAssertTrue(detailSource.contains("onRepairP2PTrust"))
        XCTAssertTrue(detailSource.contains("修复 P2P 信任"))
        XCTAssertTrue(detailSource.contains("Repair P2P Trust"))
        XCTAssertTrue(detailSource.contains("彻底忘记设备"))
        XCTAssertTrue(detailSource.contains("Forget Device"))
        XCTAssertFalse(detailSource.contains("Label(ui(chinese: \"移除信任\""))

        XCTAssertTrue(discoverySource.contains("PeerBootstrapTrustMaterialCleanup.repairP2PTrust(deviceIds: idsToRepair)"))
        XCTAssertTrue(discoverySource.contains("let idsToForget = Array(Set(idsToRevoke + [declaredDeviceId].compactMap { $0 }))"))
        XCTAssertTrue(discoverySource.contains("PeerBootstrapTrustMaterialCleanup.forgetDevice(deviceIds: idsToForget)"))

        let repairRange = try XCTUnwrap(discoverySource.range(of: "onRepairP2PTrust"))
        let repairCleanupRange = try XCTUnwrap(discoverySource.range(of: "PeerBootstrapTrustMaterialCleanup.repairP2PTrust"))
        let forgetRange = try XCTUnwrap(discoverySource.range(of: "onRemoveTrust"))
        let forgetCleanupRange = try XCTUnwrap(discoverySource.range(of: "PeerBootstrapTrustMaterialCleanup.forgetDevice"))

        XCTAssertLessThan(repairRange.lowerBound, repairCleanupRange.lowerBound)
        XCTAssertLessThan(forgetRange.lowerBound, forgetCleanupRange.lowerBound)
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
