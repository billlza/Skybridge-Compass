import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class RemoteControlStartupTimingTests: XCTestCase {
    func testInitialConfigurationAllowsTheWholeHostApprovalWindow() {
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: "startup", transportKind: .p2p, remoteIPAddress: "192.0.2.1",
            remoteDeviceId: "viewer", remoteDeviceName: "Viewer",
            remoteAccountDisplayName: "Account", remoteNebulaId: "NEBULA-TEST",
            localAccountDisplayName: "Host", localNebulaId: "NEBULA-HOST",
            cryptoSuite: "ML-KEM-768"
        )
        let transportBudgets: [Duration] = [.seconds(10), .seconds(30)]
        for transportBudget in transportBudgets {
            let deadline = RemoteControlStartupTiming.acknowledgementTimeout(
                hasApprovedSession: false, configurationTimeout: transportBudget
            )
            XCTAssertGreaterThanOrEqual(
                deadline,
                .seconds(descriptor.approvalTimeoutSeconds)
                    + RemoteControlStartupTiming.noticeIdentityTimeout + transportBudget
            )
        }
    }

    func testLegacyAndManagedAcknowledgementsRestoreTheTransportBudget() throws {
        let grants: [RemoteControlAccess?] = [nil, try RemoteControlAccess(revision: 1, role: .observer, lease: nil)]
        for access in grants {
            var tracker = RemoteControlAccessTracker()
            XCTAssertFalse(tracker.canSendInput)
            _ = try tracker.accept(access)
            let budgets: [Duration] = [.seconds(10), .seconds(30)]
            for budget in budgets {
                XCTAssertEqual(
                    RemoteControlStartupTiming.acknowledgementTimeout(
                        hasApprovedSession: tracker.hasAcknowledgement, configurationTimeout: budget
                    ), budget
                )
            }
        }
    }

    func testAReplacementSessionMustWaitForApprovalAgain() throws {
        var tracker = RemoteControlAccessTracker()
        _ = try tracker.accept(nil)
        tracker = RemoteControlAccessTracker()
        XCTAssertGreaterThan(
            RemoteControlStartupTiming.acknowledgementTimeout(
                hasApprovedSession: tracker.hasAcknowledgement, configurationTimeout: .seconds(10)
            ), .seconds(10)
        )
        XCTAssertFalse(tracker.canSendInput)
    }
}
