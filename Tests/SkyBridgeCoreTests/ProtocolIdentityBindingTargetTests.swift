import XCTest
@testable import SkyBridgeProtocolCore

final class ProtocolIdentityBindingTargetTests: XCTestCase {
    private let deviceID = "aabbccdd-1111-4222-8333-444455556666"

    func testCaseAndIdentityWrapperUseOneStableIdentityWithoutRewritingTarget() throws {
        for target in [deviceID, deviceID.uppercased(), "id:" + deviceID, "ID:" + deviceID.uppercased()] {
            let aliases = try XCTUnwrap(ProtocolIdentityBindingTarget.candidateAliases(
                targetDeviceId: target, localId: "id:" + deviceID, aliases: [deviceID]
            ))
            XCTAssertTrue(aliases.contains(target))
            XCTAssertEqual(Set(aliases.compactMap(PeerIdentityFusionPolicy.normalizedStableDeviceId)), ["id:" + deviceID])
        }
    }

    func testEstablishedStableAliasCanIdentifyResponderButUnknownIdCannot() throws {
        let established = "id:previous-device-identity"
        let aliases = try XCTUnwrap(ProtocolIdentityBindingTarget.candidateAliases(
            targetDeviceId: "PREVIOUS-DEVICE-IDENTITY", localId: deviceID, aliases: [established]
        ))
        XCTAssertTrue(aliases.contains("PREVIOUS-DEVICE-IDENTITY"))
        XCTAssertNil(ProtocolIdentityBindingTarget.candidateAliases(
            targetDeviceId: "id:unrelated-device-identity", localId: deviceID, aliases: [established]
        ))
    }

    func testEndpointAliasNeverBecomesAuthorityEvenWhenPreviouslyListed() {
        let endpoints = ["host:Studio", "peer:192.0.2.1", "bonjour:Studio@local.", "recent:Studio",
                         "192.0.2.1", "id:192.0.2.1", "2130706433", "id:2130706433", "fe80::1",
                         "id:host:Studio", "device@example.local"]
        for endpoint in endpoints {
            XCTAssertNil(ProtocolIdentityBindingTarget.candidateAliases(
                targetDeviceId: endpoint, localId: deviceID, aliases: endpoints
            ), endpoint)
        }
    }

    func testInvalidLocalAuthorityCannotBeReplacedByAnAlias() {
        for local in ["", "host:Studio", "id:192.0.2.1"] {
            XCTAssertNil(ProtocolIdentityBindingTarget.candidateAliases(
                targetDeviceId: deviceID, localId: local, aliases: [deviceID]
            ))
        }
    }

    func testInvalidTargetCannotEnterSignedAliasList() {
        for target in ["", "   ", "id:id:" + deviceID, deviceID + "\nother", deviceID + "=other", "id:短标识测试测试测试"] {
            XCTAssertNil(ProtocolIdentityBindingTarget.candidateAliases(
                targetDeviceId: target, localId: deviceID, aliases: [target]
            ))
        }
    }

    func testSignedAliasesAreStableDeduplicatedAndIncludeOnlyTrimmedOriginalTarget() throws {
        let target = "  " + deviceID.uppercased() + "  "
        let aliases = try XCTUnwrap(ProtocolIdentityBindingTarget.candidateAliases(
            targetDeviceId: target, localId: "id:" + deviceID,
            aliases: [deviceID, deviceID, "host:Studio", "192.0.2.1", " " + deviceID + " "]
        ))
        XCTAssertEqual(aliases, Array(Set([deviceID, "id:" + deviceID, deviceID.uppercased()])).sorted())
        XCTAssertFalse(aliases.contains(target))
    }
}
