import Network
import XCTest
@testable import SkyBridgeCore
import dnssd

final class NetworkFrameworkLocalNetworkPermissionClassifierTests: XCTestCase {
    func testLocalNetworkUnsatisfiedReasonIsClassifiedAsPermissionDenied() {
        XCTAssertTrue(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                unsatisfiedReason: .localNetworkDenied
            )
        )
        XCTAssertFalse(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                unsatisfiedReason: .wifiDenied
            )
        )
        XCTAssertFalse(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                unsatisfiedReason: nil
            )
        )
    }

    func testNetworkFrameworkTextFallbackRecognizesOnlyLocalNetworkDenial() {
        XCTAssertTrue(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                errorDescriptions: ["Local network prohibited by privacy settings"]
            )
        )
        XCTAssertTrue(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                errorDescriptions: ["unsatisfiedReason=LocalNetworkDenied"]
            )
        )
        XCTAssertFalse(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                errorDescriptions: ["The Internet connection appears to be offline"]
            )
        )
    }

    func testDNSServicePolicyDenialIsClassifiedWithoutLocalizedText() {
        XCTAssertTrue(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                error: .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)),
                path: nil
            )
        )
        XCTAssertFalse(
            NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(
                error: .dns(DNSServiceErrorType(kDNSServiceErr_Timeout)),
                path: nil
            )
        )
    }
}
