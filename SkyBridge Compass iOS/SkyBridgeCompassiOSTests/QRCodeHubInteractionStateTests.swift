import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class QRCodeHubInteractionStateTests: XCTestCase {
    func testConnectionCodeFailureClearsSubmittingAndCapturesSheetError() {
        var state = QRCodeHubInteractionState()
        state.startConnectionCodeSubmission()

        state.handleCrossNetworkState(.failed("missing authentication"))

        XCTAssertFalse(state.isSubmittingCode)
        XCTAssertFalse(state.isConnecting)
        XCTAssertEqual(state.sheetErrorMessage, "missing authentication")
    }

    func testScannedConnectLinkFailureClearsSubmittingAndCapturesSheetError() {
        var state = QRCodeHubInteractionState()
        state.startScannedConnectLinkSubmission()

        state.handleCrossNetworkState(.failed("identity conflict"))

        XCTAssertFalse(state.isSubmittingScannedConnectLink)
        XCTAssertFalse(state.isSubmittingCode)
        XCTAssertFalse(state.isConnecting)
        XCTAssertEqual(state.sheetErrorMessage, "identity conflict")
    }

    func testIPadRegressionModeChangeAfterConnectionCodeFailureClearsBlockingSheetState() {
        var state = QRCodeHubInteractionState()
        state.startConnectionCodeSubmission()
        state.handleCrossNetworkState(.failed("code lookup failed"))

        state.resetForModeChange()

        XCTAssertFalse(state.isSubmittingCode)
        XCTAssertFalse(state.isConnecting)
        XCTAssertNil(state.sheetErrorMessage)
    }

    func testHandshakeCompletionRequestsSheetDismissal() {
        var state = QRCodeHubInteractionState()
        state.startScannedConnectLinkSubmission()

        let shouldDismiss = state.handleReadiness(.handshakeComplete(sessionId: "session-1", negotiatedSuite: "X-Wing"))

        XCTAssertTrue(shouldDismiss)
        XCTAssertFalse(state.isSubmittingScannedConnectLink)
    }

    func testIdleReadinessClearsScannedConnectLinkSubmissionState() {
        var state = QRCodeHubInteractionState()
        state.startScannedConnectLinkSubmission()

        let shouldDismiss = state.handleReadiness(.idle)

        XCTAssertFalse(shouldDismiss)
        XCTAssertFalse(state.isSubmittingScannedConnectLink)
    }

    func testLegacyUnsignedPairingQRCodeIsMarkedAsUnsignedLegacy() {
        let data = QRCodeData(
            type: .devicePairing,
            deviceId: UUID().uuidString,
            deviceName: "Legacy Device",
            ipAddress: "192.168.1.20",
            port: 9527,
            publicKey: nil,
            timestamp: Date().timeIntervalSince1970,
            expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970
        )

        XCTAssertEqual(data.validateDevicePairingSecurity(), .unsignedLegacy)
    }

    func testAuthenticatedPairingQRCodeVerifiesSuccessfully() throws {
        let data = try QRCodeGenerator.shared.createAuthenticatedPairingData(
            deviceId: UUID().uuidString,
            deviceName: "Verified Device",
            ipAddress: "192.168.1.30",
            port: 9527
        )

        XCTAssertEqual(data.validateDevicePairingSecurity(), .verified)
    }

    func testTamperedAuthenticatedPairingQRCodeFailsVerification() throws {
        let original = try QRCodeGenerator.shared.createAuthenticatedPairingData(
            deviceId: UUID().uuidString,
            deviceName: "Verified Device",
            ipAddress: "192.168.1.40",
            port: 9527
        )
        let tampered = QRCodeData(
            type: original.type,
            deviceId: original.deviceId,
            deviceName: "Tampered Device",
            ipAddress: original.ipAddress,
            port: original.port,
            publicKey: original.publicKey,
            timestamp: original.timestamp,
            expiresAt: original.expiresAt,
            signature: original.signature,
            signatureVersion: original.signatureVersion,
            payload: original.payload
        )

        switch tampered.validateDevicePairingSecurity() {
        case .invalid(let reason):
            XCTAssertFalse(reason.isEmpty)
        default:
            XCTFail("Expected tampered QR code to fail signature validation")
        }
    }
}
