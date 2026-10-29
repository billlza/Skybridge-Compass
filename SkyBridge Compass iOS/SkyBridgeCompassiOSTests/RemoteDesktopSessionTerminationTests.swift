import Foundation
import XCTest
import SkyBridgeProtocolCore

final class RemoteDesktopSessionTerminationTests: XCTestCase {
    private let transaction = RemoteDesktopStreamConfigurationTransaction(id: UUID(uuidString: "11223344-5566-7788-99AA-BBCCDDEEFF00")!)
    private func fixture() throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "session-ended-v1", withExtension: "json")))
    }
    func testSharedGoldenAndExactTransaction() throws {
        let value = try JSONDecoder().decode(RemoteDesktopSessionTermination.self, from: fixture())
        XCTAssertEqual(value.transaction, transaction)
        XCTAssertEqual(value.reason, .userStopped)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(value), try fixture().dropLast())
        try XCTUnwrap(RemoteDesktopSessionTerminationContract(version: 1, transaction: transaction)).validate(value)
    }
    func testReplacedTransactionIsRejected() throws {
        let value = try JSONDecoder().decode(RemoteDesktopSessionTermination.self, from: fixture())
        let replacement = try XCTUnwrap(RemoteDesktopSessionTerminationContract(version: 1, transaction: .init()))
        XCTAssertThrowsError(try replacement.validate(value))
    }
    func testMissingUnknownVersionAndUnknownReasonAreRejected() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        for version in [0, 2, -1] {
            json["version"] = version
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteDesktopSessionTermination.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        json.removeValue(forKey: "version")
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteDesktopSessionTermination.self, from: JSONSerialization.data(withJSONObject: json)))
        json["version"] = 1; json["reason"] = "everything is fine"
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteDesktopSessionTermination.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testOldEndpointDoesNotGrantTerminationAndUnknownCapabilityFails() throws {
        XCTAssertNil(RemoteDesktopSessionTerminationContract(version: nil, transaction: transaction))
        XCTAssertNil(try RemoteDesktopSessionTerminationContract.negotiatedVersion(requested: nil))
        XCTAssertThrowsError(try RemoteDesktopSessionTerminationContract.negotiatedVersion(requested: 2))
        XCTAssertTrue(RemoteDesktopSessionTerminationContract.acknowledgementMatches(requested: 1, acknowledged: nil))
        XCTAssertTrue(RemoteDesktopSessionTerminationContract.acknowledgementMatches(requested: 1, acknowledged: 1))
        XCTAssertFalse(RemoteDesktopSessionTerminationContract.acknowledgementMatches(requested: nil, acknowledged: 1))
        XCTAssertFalse(RemoteDesktopSessionTerminationContract.acknowledgementMatches(requested: 1, acknowledged: 2))
    }
    func testCaptureFailureCannotBePresentedAsNormalStop() {
        XCTAssertTrue(RemoteDesktopSessionTermination.Reason.captureFailed.isFailure)
        XCTAssertFalse(RemoteDesktopSessionTermination.Reason.userStopped.isFailure)
        XCTAssertFalse(RemoteDesktopSessionTermination.Reason.permissionRevoked.isFailure)
    }
}
