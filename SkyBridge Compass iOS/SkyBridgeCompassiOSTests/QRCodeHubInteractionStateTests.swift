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

        let shouldDismiss = state.handleReadiness(.handshakeComplete(sessionId: "session-1", negotiatedSuite: "X-Wing"))

        XCTAssertTrue(shouldDismiss)
    }
}
