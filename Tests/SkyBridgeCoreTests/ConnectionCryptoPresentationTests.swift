import XCTest
@testable import SkyBridgeCore

final class ConnectionCryptoPresentationTests: XCTestCase {
    func testXWingSuiteConnectedStatus() {
        let text = ConnectionCryptoPresentation.connectedStatusText(
            kind: nil,
            suite: "X-Wing",
            baseConnectedText: "已连接"
        )

        XCTAssertEqual(text, "X-Wing已连接")
    }

    func testClassicSuiteConnectedStatus() {
        let text = ConnectionCryptoPresentation.connectedStatusText(
            kind: nil,
            suite: "X25519",
            baseConnectedText: "已连接"
        )

        XCTAssertEqual(text, "Classic已连接")
    }

    func testLegacyAppleKindIsNormalized() {
        let text = ConnectionCryptoPresentation.connectedStatusText(
            kind: "ApplePQC",
            suite: "ML-KEM-768",
            baseConnectedText: "已连接"
        )

        XCTAssertEqual(text, "Apple PQC已连接")
    }

    func testAppleKindWithoutNegotiatedSuiteDoesNotClaimPQC() {
        let text = ConnectionCryptoPresentation.connectedStatusText(
            kind: "ApplePQC",
            suite: nil,
            baseConnectedText: "已连接"
        )

        XCTAssertEqual(text, "已连接")
    }

    func testLiboqsKindConnectedStatus() {
        let text = ConnectionCryptoPresentation.connectedStatusText(
            kind: "liboqs",
            suite: "ML-KEM-768",
            baseConnectedText: "已连接"
        )

        XCTAssertEqual(text, "liboqs已连接")
    }

    func testModeLabelDoesNotInferProviderFromCapabilityForPQCOnlySuite() {
        let appleCapability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "macOS 26"
        )
        let liboqsCapability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: true,
            osVersion: "macOS 15"
        )

        XCTAssertEqual(
            ConnectionCryptoPresentation.modeLabel(kind: nil, suite: "ML-KEM-768", capability: appleCapability),
            "PQC"
        )
        XCTAssertEqual(
            ConnectionCryptoPresentation.modeLabel(kind: nil, suite: "ML-KEM-768", capability: liboqsCapability),
            "PQC"
        )
    }

    func testDetailTextSuppressesDuplicateSuiteLabel() {
        let detail = ConnectionCryptoPresentation.detailText(
            kind: "X-Wing",
            suite: "xwing",
            guardStatus: "守护中"
        )

        XCTAssertEqual(detail, "X-Wing · 守护中")
    }

    func testConnectedStatusTextWithPolicyFallbackKeepsExplicitMode() {
        let text = ConnectionCryptoPresentation.connectedStatusTextWithPolicyFallback(
            kind: "liboqs",
            suite: nil,
            baseConnectedText: "已连接",
            compatibilityModeEnabled: true
        )

        XCTAssertEqual(text, "liboqs已连接")
    }

    func testConnectedStatusTextWithPolicyFallbackDoesNotClaimPQCWithoutSessionEvidence() {
        let text = ConnectionCryptoPresentation.connectedStatusTextWithPolicyFallback(
            kind: nil,
            suite: nil,
            baseConnectedText: "已连接",
            compatibilityModeEnabled: false
        )

        XCTAssertEqual(text, "已连接")
    }

    func testModeLabelDoesNotInferApplePQCFromProviderNameAlone() {
        XCTAssertNil(ConnectionCryptoPresentation.modeLabel(kind: "ApplePQC", suite: nil))
    }
}
