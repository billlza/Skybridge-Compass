import Foundation
import XCTest
@testable import SkyBridgeCore

final class P2PConnectionAttemptOwnershipTests: XCTestCase {
    func testReplacementAttemptCannotBeRemovedByEarlierCompletion() {
        var ownership = P2PConnectionAttemptOwnershipState()
        let deviceId = "peer-\(UUID().uuidString.lowercased())"

        let first = ownership.begin(deviceId: deviceId)
        let replacement = ownership.begin(deviceId: deviceId)

        XCTAssertFalse(ownership.isCurrent(first, deviceId: deviceId))
        XCTAssertTrue(ownership.isCurrent(replacement, deviceId: deviceId))
        XCTAssertFalse(ownership.finishIfCurrent(first, deviceId: deviceId))
        XCTAssertTrue(
            ownership.isCurrent(replacement, deviceId: deviceId),
            "a stale completion must not remove the replacement attempt"
        )
        XCTAssertTrue(ownership.finishIfCurrent(replacement, deviceId: deviceId))
        XCTAssertFalse(ownership.isCurrent(replacement, deviceId: deviceId))
    }

    func testExplicitCancellationInvalidatesOnlyTheTargetDeviceAttempt() {
        var ownership = P2PConnectionAttemptOwnershipState()
        let firstDeviceId = "peer-a-\(UUID().uuidString.lowercased())"
        let secondDeviceId = "peer-b-\(UUID().uuidString.lowercased())"
        let first = ownership.begin(deviceId: firstDeviceId)
        let second = ownership.begin(deviceId: secondDeviceId)

        ownership.cancel(deviceId: firstDeviceId)

        XCTAssertFalse(ownership.isCurrent(first, deviceId: firstDeviceId))
        XCTAssertTrue(ownership.isCurrent(second, deviceId: secondDeviceId))
    }

    func testNetworkManagerWiresOwnershipThroughEveryConnectionSideEffect() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PNetworkManager.swift"
        )

        XCTAssertTrue(source.contains("connectionAttemptTasksByDeviceId[deviceCopy.deviceId]?.cancel()"))
        XCTAssertTrue(source.contains("connectionAttemptOwnership.begin(deviceId: deviceCopy.deviceId)"))
        XCTAssertTrue(source.contains("connectionAttemptOwnership.isCurrent("))
        XCTAssertTrue(source.contains("connectionAttemptOwnership.finishIfCurrent("))
        XCTAssertTrue(source.contains("self.activeConnections[deviceCopy.deviceId] === connection"))
        XCTAssertTrue(source.contains("self.activeConnections[deviceCopy.deviceId] === attemptConnection"))
        XCTAssertTrue(source.contains("if stored === connection"))
        XCTAssertTrue(source.contains("connectionAttemptOwnership.removeAll()"))
        XCTAssertFalse(
            source.contains("activeConnections.removeValue(forKey: connection.device.deviceId)"),
            "An old completion must never remove a replacement by key alone."
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
